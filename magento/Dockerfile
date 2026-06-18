FROM php:8.2-fpm-bookworm AS runtime

ARG HOST_UID=1001
ARG HOST_GID=1001

RUN apt-get update && apt-get install -y --no-install-recommends \
    libicu-dev libzip-dev libonig-dev \
    libxml2-dev libxslt1-dev \
    libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
    libssl-dev \
    git unzip curl nano \
    default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-configure gd \
      --with-freetype \
      --with-jpeg && \
    docker-php-ext-install -j$(nproc) \
      bcmath \
      gd \
      intl \
      mysqli \
      opcache \
      pdo \
      pdo_mysql \
      soap \
      sockets \
      xsl \
      zip

RUN pecl install redis && docker-php-ext-enable redis

COPY --from=composer:2.7 /usr/bin/composer /usr/bin/composer

RUN groupadd -g ${HOST_GID} clp 2>/dev/null || true && \
    useradd -u ${HOST_UID} -g clp -s /bin/bash -m test-ssh 2>/dev/null || true

RUN mkdir -p /var/run/php-fpm && \
    chown test-ssh:clp /var/run/php-fpm

RUN mkdir -p /var/www/html && \
    chown -R test-ssh:clp /var/www/html

COPY run-cron.sh /usr/local/bin/run-cron.sh
RUN chmod +x /usr/local/bin/run-cron.sh

RUN rm -f /usr/local/etc/php-fpm.d/www.conf

WORKDIR /var/www/html

USER test-ssh:clp

EXPOSE 9000

CMD ["php-fpm", "--nodaemonize"]
