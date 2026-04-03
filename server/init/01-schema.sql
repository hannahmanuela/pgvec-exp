CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS items (
    id        BIGSERIAL PRIMARY KEY,
    embedding vector(768)
);

-- HNSW index on L2 distance.
-- m=16 and ef_construction=64 are pgvector defaults.
-- Raise ef_construction (e.g. 128) for higher recall at the cost of build time.
CREATE INDEX IF NOT EXISTS items_embedding_hnsw_idx
    ON items
    USING hnsw (embedding vector_l2_ops)
    WITH (m = 16, ef_construction = 64);
