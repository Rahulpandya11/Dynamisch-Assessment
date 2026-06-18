FROM varnish:7.5-alpine

COPY default.vcl /etc/varnish/default.vcl

EXPOSE 6081 6082

CMD ["varnishd", \
     "-F", \
     "-f", "/etc/varnish/default.vcl", \
     "-s", "malloc,128m", \
     "-a", "0.0.0.0:6081", \
     "-T", "0.0.0.0:6082"]
