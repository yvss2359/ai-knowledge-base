-- ============================================================
-- Extensions
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- recherche full-text sur les documents

-- ============================================================
-- USERS
-- ============================================================
CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email         VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    full_name     VARCHAR(100) NOT NULL,
    avatar_url    VARCHAR(500),
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_email ON users(email);

-- ============================================================
-- WORKSPACES
-- ============================================================
CREATE TABLE workspaces (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        VARCHAR(100) NOT NULL,
    slug        VARCHAR(100) NOT NULL UNIQUE,  -- URL-friendly: "acme-corp"
    description TEXT,
    owner_id    UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_workspaces_owner ON workspaces(owner_id);

-- ============================================================
-- WORKSPACE_MEMBERS  (table de jointure enrichie)
-- ============================================================
CREATE TYPE workspace_role AS ENUM ('OWNER', 'ADMIN', 'MEMBER', 'VIEWER');

CREATE TABLE workspace_members (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id)      ON DELETE CASCADE,
    role         workspace_role NOT NULL DEFAULT 'MEMBER',
    joined_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, user_id)
);

CREATE INDEX idx_wm_workspace ON workspace_members(workspace_id);
CREATE INDEX idx_wm_user      ON workspace_members(user_id);

-- ============================================================
-- TAGS
-- ============================================================
CREATE TABLE tags (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name         VARCHAR(50) NOT NULL,
    color        VARCHAR(7) NOT NULL DEFAULT '#6366f1', -- hex couleur
    UNIQUE (workspace_id, name)
);

-- ============================================================
-- DOCUMENTS
-- ============================================================
CREATE TYPE document_status AS ENUM (
    'DRAFT',
    'PUBLISHED',
    'PROCESSING',   -- pipeline IA en cours
    'INDEXED',      -- embeddings stockés dans Qdrant
    'ERROR'
);

CREATE TYPE file_type AS ENUM ('PDF', 'DOCX', 'TXT', 'MARKDOWN', 'NONE');

CREATE TABLE documents (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id     UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    author_id        UUID NOT NULL REFERENCES users(id)      ON DELETE RESTRICT,
    title            VARCHAR(500) NOT NULL,
    content_markdown TEXT,                    -- contenu édité en Markdown
    file_url         VARCHAR(1000),           -- S3/MinIO key si fichier uploadé
    file_type        file_type NOT NULL DEFAULT 'NONE',
    status           document_status NOT NULL DEFAULT 'DRAFT',
    metadata         JSONB NOT NULL DEFAULT '{}',
    view_count       INTEGER NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index full-text pour la recherche textuelle (complémentaire au RAG)
CREATE INDEX idx_documents_workspace  ON documents(workspace_id);
CREATE INDEX idx_documents_author     ON documents(author_id);
CREATE INDEX idx_documents_status     ON documents(status);
CREATE INDEX idx_documents_fts        ON documents USING gin(to_tsvector('french', title || ' ' || COALESCE(content_markdown, '')));
CREATE INDEX idx_documents_metadata   ON documents USING gin(metadata);

-- ============================================================
-- DOCUMENT_TAGS  (many-to-many)
-- ============================================================
CREATE TABLE document_tags (
    document_id UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    tag_id      UUID NOT NULL REFERENCES tags(id)      ON DELETE CASCADE,
    PRIMARY KEY (document_id, tag_id)
);

-- ============================================================
-- DOCUMENT_CHUNKS  (fragments pour le RAG)
-- ============================================================
CREATE TABLE document_chunks (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    document_id      UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    chunk_index      INTEGER NOT NULL,       -- ordre dans le document
    content          TEXT NOT NULL,          -- texte du fragment
    qdrant_vector_id VARCHAR(100),           -- ID du point dans Qdrant
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (document_id, chunk_index)
);

CREATE INDEX idx_chunks_document ON document_chunks(document_id);

-- ============================================================
-- CHAT_SESSIONS
-- ============================================================
CREATE TABLE chat_sessions (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id)      ON DELETE CASCADE,
    title        VARCHAR(200) NOT NULL DEFAULT 'Nouvelle conversation',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sessions_workspace ON chat_sessions(workspace_id);
CREATE INDEX idx_sessions_user      ON chat_sessions(user_id);

-- ============================================================
-- MESSAGES
-- ============================================================
CREATE TYPE message_role AS ENUM ('USER', 'ASSISTANT', 'SYSTEM');

CREATE TABLE messages (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id    UUID NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
    role          message_role NOT NULL,
    content       TEXT NOT NULL,
    source_chunks JSONB,   -- [{chunk_id, document_id, document_title, score}]
    tokens_used   INTEGER,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_messages_session    ON messages(session_id);
CREATE INDEX idx_messages_created_at ON messages(created_at);

-- ============================================================
-- COMMENTS  (avec support de réponses imbriquées)
-- ============================================================
CREATE TABLE comments (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    document_id UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    author_id   UUID NOT NULL REFERENCES users(id)     ON DELETE RESTRICT,
    content     TEXT NOT NULL,
    parent_id   UUID REFERENCES comments(id) ON DELETE CASCADE, -- NULL = commentaire racine
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_comments_document ON comments(document_id);
CREATE INDEX idx_comments_parent   ON comments(parent_id);

-- ============================================================
-- ANALYTICS_EVENTS  (append-only, jamais de UPDATE)
-- ============================================================
CREATE TYPE event_type AS ENUM (
    'DOCUMENT_VIEWED',
    'DOCUMENT_CREATED',
    'DOCUMENT_UPDATED',
    'CHAT_MESSAGE_SENT',
    'SEARCH_PERFORMED',
    'FILE_UPLOADED'
);

CREATE TABLE analytics_events (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    user_id      UUID REFERENCES users(id) ON DELETE SET NULL,
    event_type   event_type NOT NULL,
    entity_id    UUID,           -- ID du document/session/etc. concerné
    entity_type  VARCHAR(50),    -- 'document', 'chat_session', etc.
    metadata     JSONB NOT NULL DEFAULT '{}',
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Partition par mois en production (optionnel mais conseillé dès le départ)
CREATE INDEX idx_events_workspace   ON analytics_events(workspace_id);
CREATE INDEX idx_events_type        ON analytics_events(event_type);
CREATE INDEX idx_events_occurred_at ON analytics_events(occurred_at DESC);

-- ============================================================
-- TRIGGER : updated_at automatique
-- ============================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_documents_updated_at
    BEFORE UPDATE ON documents
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
