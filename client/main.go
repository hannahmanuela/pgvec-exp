package main

import (
	"context"
	"encoding/csv"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	pgvector "github.com/pgvector/pgvector-go"
	pgxvec "github.com/pgvector/pgvector-go/pgx"
)

type sample struct {
	sentAt    int64 // unix nanoseconds, captured at dispatch time
	latencyUs int64 // microseconds from dispatch to response
	status    string
}

func main() {
	host := flag.String("host", "localhost", "Postgres host")
	port := flag.Int("port", 5432, "Postgres port")
	user := flag.String("user", "bench", "Postgres user")
	password := flag.String("password", "bench", "Postgres password")
	dbname := flag.String("dbname", "benchdb", "Postgres database")
	targetRate := flag.Float64("rate", 100, "Target requests per second")
	duration := flag.Int("duration", 60, "Test duration in seconds")
	rampUp := flag.Int("ramp-up", 10, "Ramp-up duration in seconds; rate increases linearly from 0 to target before the timed test")
	workers := flag.Int("workers", 50, "Worker goroutine pool size")
	dim     := flag.Int("dim", 768, "Query vector dimension")
	outDir  := flag.String("out", "out", "Directory to write results CSV")
	flag.Parse()

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		log.Fatalf("create output dir: %v", err)
	}

	csvPath := filepath.Join(*outDir, "srv_times.txt")
	f, err := os.Create(csvPath)
	if err != nil {
		log.Fatalf("create csv: %v", err)
	}
	defer f.Close()

	dsn := fmt.Sprintf("postgres://%s:%s@%s:%d/%s", *user, *password, *host, *port, *dbname)
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		log.Fatalf("parse config: %v", err)
	}
	cfg.MaxConns = int32(*workers + 2)
	cfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		return pgxvec.RegisterTypes(ctx, conn)
	}

	ctx := context.Background()
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("ping: %v", err)
	}

	// CSV writer goroutine: single writer avoids lock contention on the file.
	// Latencies are also accumulated here for the post-run summary.
	samples := make(chan sample, 8192)
	var latencies []int64
	var errCount int64
	var writerDone sync.WaitGroup
	writerDone.Add(1)
	go func() {
		defer writerDone.Done()
		w := csv.NewWriter(f)
		_ = w.Write([]string{"sent_at_unix_ns", "latency_us", "status"})
		for s := range samples {
			_ = w.Write([]string{
				strconv.FormatInt(s.sentAt, 10),
				strconv.FormatInt(s.latencyUs, 10),
				s.status,
			})
			latencies = append(latencies, s.latencyUs)
			if s.status != "ok" {
				errCount++
			}
		}
		w.Flush()
	}()

	// Dispatcher: Poisson arrivals via exponential inter-arrival times (mean = 1/rate).
	// During ramp-up the instantaneous rate increases linearly from 1 req/s to targetRate.
	// sentAt is captured here (dispatch time), not when the worker dequeues the job,
	// so latency includes any time spent waiting for a free worker.
	jobs := make(chan int64, *workers)
	var dropped int64
	go func() {
		defer close(jobs)

		dispRng := rand.New(rand.NewSource(12))
		rampDur := time.Duration(*rampUp) * time.Second
		rampStart := time.Now()
		deadline := rampStart.Add(rampDur + time.Duration(*duration)*time.Second)

		for time.Now().Before(deadline) {
			// Linearly ramp up the rate during the ramp-up window.
			var currentRate float64
			if *rampUp > 0 {
				elapsed := time.Since(rampStart)
				if elapsed < rampDur {
					frac := float64(elapsed) / float64(rampDur)
					currentRate = frac * *targetRate
					if currentRate < 1 {
						currentRate = 1
					}
				} else {
					currentRate = *targetRate
				}
			} else {
				currentRate = *targetRate
			}

			// Sample next inter-arrival time from Exp(currentRate).
			interval := time.Duration(dispRng.ExpFloat64() / currentRate * float64(time.Second))
			time.Sleep(interval)

			sentAt := time.Now().UnixNano()
			select {
			case jobs <- sentAt:
			default:
				// All workers busy and channel full: record as dropped and continue.
				atomic.AddInt64(&dropped, 1)
			}
		}
	}()

	// Worker pool: goroutines pull jobs and execute queries independently of the
	// dispatch rate (open-loop — workers never sleep between requests).
	const query = "SELECT id FROM items ORDER BY embedding <-> $1 LIMIT 10"
	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(int64(id)))
			for sentAt := range jobs {
				vec := randVector(rng, *dim)
				qCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
				rows, queryErr := pool.Query(qCtx, query, pgvector.NewVector(vec))
				cancel()

				status := "ok"
				if queryErr != nil {
					status = "error"
				} else {
					for rows.Next() {
						var id int64
						rows.Scan(&id) //nolint — result discarded
					}
					rows.Close()
					if rows.Err() != nil {
						status = "error"
					}
				}
				latencyUs := (time.Now().UnixNano() - sentAt) / 1000
				samples <- sample{sentAt: sentAt, latencyUs: latencyUs, status: status}
			}
		}(i)
	}

	wg.Wait()
	close(samples)
	writerDone.Wait()

	printSummary(latencies, errCount, atomic.LoadInt64(&dropped), *targetRate, *duration, *rampUp, csvPath)
}

func randVector(rng *rand.Rand, dim int) []float32 {
	v := make([]float32, dim)
	for i := range v {
		v[i] = float32(rng.NormFloat64())
	}
	return v
}

func printSummary(latencies []int64, errCount, dropped int64, targetRate float64, duration, rampUp int, csvPath string) {
	total := int64(len(latencies))
	fmt.Printf("\n--- Results ---\n")
	fmt.Printf("Target rate:   %.1f req/s\n", targetRate)
	if rampUp > 0 {
		fmt.Printf("Ramp-up:       %ds\n", rampUp)
	}
	fmt.Printf("Duration:      %ds\n", duration)
	fmt.Printf("Completed:     %d (%.1f req/s actual)\n", total, float64(total)/float64(duration+rampUp))
	fmt.Printf("Errors:        %d\n", errCount)
	fmt.Printf("Dropped:       %d  (system saturated; all workers busy at dispatch time)\n", dropped)

	if total == 0 {
		fmt.Println("No completed requests — no latency data.")
		return
	}

	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })

	pct := func(p float64) int64 {
		idx := int(float64(total-1) * p / 100.0)
		return latencies[idx]
	}

	fmt.Printf("Latency (µs):\n")
	fmt.Printf("  p50:         %d\n", pct(50))
	fmt.Printf("  p95:         %d\n", pct(95))
	fmt.Printf("  p99:         %d\n", pct(99))
	fmt.Printf("  p99.9:       %d\n", pct(99.9))
	fmt.Printf("  max:         %d\n", latencies[total-1])
	fmt.Printf("CSV:           %s\n", csvPath)
}
