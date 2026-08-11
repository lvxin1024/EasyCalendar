CREATE TABLE candidate_extractions (
    extraction_id TEXT PRIMARY KEY,
    parser_id TEXT NOT NULL,
    source_text TEXT NOT NULL,
    candidates_json TEXT NOT NULL,
    warnings_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    rejected_at TEXT,
    rejection_reason TEXT
);

CREATE INDEX idx_candidate_extractions_created
    ON candidate_extractions(created_at, extraction_id);

CREATE TABLE candidate_confirmations (
    extraction_id TEXT NOT NULL
        REFERENCES candidate_extractions(extraction_id) ON DELETE CASCADE,
    temp_id TEXT NOT NULL,
    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
    request_hash TEXT NOT NULL,
    confirmed_at TEXT NOT NULL,
    PRIMARY KEY (extraction_id, temp_id)
);

CREATE UNIQUE INDEX idx_candidate_confirmations_item
    ON candidate_confirmations(item_id);
