# Test runner for app/: PHP 8.4 (as the app), Composer, Node and Playwright's Chromium.
# Lives outside app/ so the published app keeps no composer.json/vendor (REQ07).
FROM php:8.4-cli

RUN apt-get update \
 && apt-get install -y --no-install-recommends git unzip nodejs npm \
 && docker-php-ext-install sockets \
 && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2.11.1 /usr/bin/composer /usr/bin/composer

# Same version as "playwright" in package.json, so Pest finds this browser build.
ARG PLAYWRIGHT_VERSION=1.64.1
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npx -y "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium \
 && chmod -R a+rX /ms-playwright \
 && rm -rf /var/lib/apt/lists/* /root/.npm
