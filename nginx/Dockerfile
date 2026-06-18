FROM nginx:1.27-alpine

RUN apk add --no-cache shadow

RUN groupadd -g 1001 clp 2>/dev/null || true && \
    useradd -u 1001 -g clp -s /sbin/nologin -M test-ssh 2>/dev/null || true

RUN mkdir -p /var/cache/nginx /var/run/nginx /var/log/nginx && \
    chown -R test-ssh:clp /var/cache/nginx /var/run/nginx /var/log/nginx && \
    touch /var/run/nginx.pid && \
    chown test-ssh:clp /var/run/nginx.pid

RUN sed -i 's/user  nginx;/user test-ssh clp;/' /etc/nginx/nginx.conf && \
    rm -f /etc/nginx/conf.d/default.conf

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
