-- The 22 listings from the LarCerto MVP (an earlier HTML/JS prototype).
-- Only loaded into an empty table: the first Compose start, or Ansible when COUNT(*) = 0.
SET NAMES utf8mb4;

INSERT INTO imoveis (titulo, tipo, preco, bairro, campus, verificado, anunciante_nome, anunciante_tipo) VALUES
  ('Kitnet Centro · perto UTFPR', 'kitnet', 780.00, 'Centro', 'UTFPR', 1, 'Maria Souza', 'locador'),
  ('Studio Bonsucesso · Unicentro', 'kitnet', 850.00, 'Bonsucesso', 'Unicentro', 1, 'Imob Guarapuava', 'imobiliaria'),
  ('Ap. 1 quarto Santana', 'apartamento', 920.00, 'Santana', 'UTFPR', 1, 'Carlos Lima', 'locador'),
  ('República Industrial', 'republica', 650.00, 'Industrial', 'UTFPR', 1, 'Casa Fácil GP', 'imobiliaria'),
  ('Kitnet Batel acessível', 'kitnet', 720.00, 'Batel', 'Unicentro', 1, 'Ana Ribeiro', 'locador'),
  ('Studio Primavera', 'kitnet', 690.00, 'Primavera', 'Qualquer campus', 1, 'Morar Bem Imóveis', 'imobiliaria'),
  ('Ap. São Cristóvão', 'apartamento', 980.00, 'São Cristóvão', 'UTFPR', 1, 'Pedro Alves', 'locador'),
  ('República Vila Carli', 'republica', 580.00, 'Vila Carli', 'Unicentro', 1, 'Lar & Cia', 'imobiliaria'),
  ('Kitnet Alto da XV', 'kitnet', 750.00, 'Alto da XV', 'UTFPR', 1, 'Maria Souza', 'locador'),
  ('Studio Cascavel', 'kitnet', 710.00, 'Cascavel', 'Qualquer campus', 1, 'Imob Guarapuava', 'imobiliaria'),
  ('Ap. Jardim das Américas', 'apartamento', 1050.00, 'Jardim das Américas', 'Unicentro', 1, 'Carlos Lima', 'locador'),
  ('República Boqueirão', 'republica', 620.00, 'Boqueirão', 'UTFPR', 1, 'Casa Fácil GP', 'imobiliaria'),
  ('Kitnet Conradinho', 'kitnet', 680.00, 'Conradinho', 'Qualquer campus', 1, 'Ana Ribeiro', 'locador'),
  ('Studio Santa Cruz', 'kitnet', 800.00, 'Santa Cruz', 'Unicentro', 1, 'Morar Bem Imóveis', 'imobiliaria'),
  ('Ap. Trianon', 'apartamento', 1100.00, 'Trianon', 'UTFPR', 1, 'Pedro Alves', 'locador'),
  ('República Vila Bela', 'republica', 550.00, 'Vila Bela', 'Qualquer campus', 1, 'Lar & Cia', 'imobiliaria'),
  ('Kitnet Morro Alto', 'kitnet', 640.00, 'Morro Alto', 'Unicentro', 1, 'Maria Souza', 'locador'),
  ('Studio Dos Estados', 'kitnet', 760.00, 'Dos Estados', 'UTFPR', 1, 'Imob Guarapuava', 'imobiliaria'),
  ('Ap. Vila Jordão', 'apartamento', 890.00, 'Vila Jordão', 'Qualquer campus', 1, 'Carlos Lima', 'locador'),
  ('República Alto Cascavel', 'republica', 600.00, 'Alto Cascavel', 'UTFPR', 1, 'Casa Fácil GP', 'imobiliaria'),
  ('Kitnet Industrial Xarquinho', 'kitnet', 670.00, 'Industrial Xarquinho', 'UTFPR', 1, 'Ana Ribeiro', 'locador'),
  ('Studio NH 2000', 'kitnet', 630.00, 'Núcleo Habitacional 2000', 'Unicentro', 1, 'Morar Bem Imóveis', 'imobiliaria');
