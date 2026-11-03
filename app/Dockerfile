# Same PHP as the web VM, plus GD (JPEG/WebP) and exif for the photos.
FROM php:8.4-apache

RUN apt-get update \
 && apt-get install -y --no-install-recommends libjpeg62-turbo-dev libpng-dev libwebp-dev \
 && docker-php-ext-configure gd --with-jpeg --with-webp \
 && docker-php-ext-install gd exif pdo_mysql \
 && rm -rf /var/lib/apt/lists/* \
 && mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"

# Same layout as the VM: config.php, backend/, frontend/ and storage/ sit above the DocumentRoot.
ENV APACHE_DOCUMENT_ROOT=/var/www/larcerto/public
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
 && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

COPY apache/larcerto.conf /etc/apache2/conf-available/larcerto.conf
COPY php/larcerto.ini $PHP_INI_DIR/conf.d/larcerto.ini
RUN a2enconf larcerto

# The uploads volume inherits owner and mode from here on first start.
RUN mkdir -p /var/www/larcerto/storage/uploads \
 && chown -R www-data:www-data /var/www/larcerto/storage \
 && chmod 0750 /var/www/larcerto/storage/uploads
