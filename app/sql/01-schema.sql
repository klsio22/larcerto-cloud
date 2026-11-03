-- Single table, at most 10 columns (REQ05). Photos are files in storage/uploads/<id>/; capa holds the cover's name.
-- Runs on the first Compose start and on every Ansible apply, so it must stay idempotent.
CREATE TABLE IF NOT EXISTS imoveis (
  id              INT AUTO_INCREMENT PRIMARY KEY,
  titulo          VARCHAR(120) NOT NULL,
  tipo            ENUM('kitnet','apartamento','casa','quarto','republica') NOT NULL,
  preco           DECIMAL(8,2) NOT NULL,
  bairro          VARCHAR(60)  NOT NULL,
  campus          ENUM('UTFPR','Unicentro','Qualquer campus') NOT NULL,
  verificado      BOOLEAN NOT NULL DEFAULT 0,
  anunciante_nome VARCHAR(80)  NOT NULL,
  anunciante_tipo ENUM('locador','imobiliaria') NOT NULL,
  capa            CHAR(32) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Databases created before the photos feature get the column; no-op otherwise.
ALTER TABLE imoveis ADD COLUMN IF NOT EXISTS capa CHAR(32) NULL;
