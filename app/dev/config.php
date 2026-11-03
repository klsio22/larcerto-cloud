<?php
// Same shape as the config.php Ansible generates on the web VM.
return [
    'dsn'      => sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', getenv('DB_HOST'), getenv('DB_NAME')),
    'user'     => getenv('DB_USER'),
    'password' => getenv('DB_PASSWORD'),
];
