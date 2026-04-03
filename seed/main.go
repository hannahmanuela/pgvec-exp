package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math"
	"math/rand"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	pgvector "github.com/pgvector/pgvector-go"
	pgxvec "github.com/pgvector/pgvector-go/pgx"
)

func main() {
	host := flag.String("host", "localhost", "Postgres host")
	port := flag.Int("port", 5432, "Postgres port")
	user := flag.String("user", "bench", "Postgres user")
	password := flag.String("password", "bench", "Postgres password")
	dbname := flag.String("dbname", "benchdb", "Postgres database")
	rows := flag.Int("rows", 100000, "Number of rows to insert")
	dim := flag.Int("dim", 768, "Vector dimension")
	numClusters := flag.Int("clusters", 100, "Number of Gaussian cluster centers")
	stddev := flag.Float64("stddev", 0.05, "Per-dimension Gaussian noise stddev added to cluster centers")
	batchSize := flag.Int("batch", 500, "Rows per SendBatch call")
	flag.Parse()

	dsn := fmt.Sprintf("postgres://%s:%s@%s:%d/%s", *user, *password, *host, *port, *dbname)
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		log.Fatalf("parse config: %v", err)
	}
	cfg.MaxConns = 4
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

	rng := rand.New(rand.NewSource(time.Now().UnixNano()))

	log.Printf("Generating %d cluster centers (dim=%d, stddev=%.3f)...", *numClusters, *dim, *stddev)
	centers := make([][]float64, *numClusters)
	for i := range centers {
		centers[i] = randUnitVector(rng, *dim)
	}

	log.Printf("Inserting %d rows in batches of %d...", *rows, *batchSize)
	start := time.Now()
	inserted := 0

	for inserted < *rows {
		end := inserted + *batchSize
		if end > *rows {
			end = *rows
		}
		count := end - inserted

		batch := &pgx.Batch{}
		for i := 0; i < count; i++ {
			center := centers[rng.Intn(*numClusters)]
			v := clusterMember(rng, center, *stddev)
			batch.Queue("INSERT INTO items (embedding) VALUES ($1)", pgvector.NewVector(v))
		}

		br := pool.SendBatch(ctx, batch)
		for i := 0; i < count; i++ {
			if _, err := br.Exec(); err != nil {
				br.Close()
				log.Fatalf("insert at row %d: %v", inserted+i, err)
			}
		}
		if err := br.Close(); err != nil {
			log.Fatalf("close batch: %v", err)
		}

		inserted = end
		if inserted == *rows || inserted%10000 == 0 {
			elapsed := time.Since(start)
			rate := float64(inserted) / elapsed.Seconds()
			log.Printf("  %d / %d rows (%.0f rows/s)", inserted, *rows, rate)
		}
	}

	log.Printf("Done: %d rows in %s", inserted, time.Since(start).Round(time.Millisecond))
}

// randUnitVector returns a unit vector sampled uniformly on the dim-sphere
// using the standard Gaussian projection trick.
func randUnitVector(rng *rand.Rand, dim int) []float64 {
	v := make([]float64, dim)
	var sumSq float64
	for i := range v {
		v[i] = rng.NormFloat64()
		sumSq += v[i] * v[i]
	}
	norm := math.Sqrt(sumSq)
	for i := range v {
		v[i] /= norm
	}
	return v
}

// clusterMember returns a float32 vector near center with independent
// Gaussian noise of the given per-dimension stddev.
func clusterMember(rng *rand.Rand, center []float64, stddev float64) []float32 {
	v := make([]float32, len(center))
	for i, c := range center {
		v[i] = float32(c + rng.NormFloat64()*stddev)
	}
	return v
}
