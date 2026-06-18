vcl 4.1;

import std;

backend default {
    .host = "nginx";
    .port = "8080";
    .connect_timeout    = 300s;
    .first_byte_timeout = 300s;
    .between_bytes_timeout = 300s;
}

acl purge {
    "localhost";
    "127.0.0.1";
    "10.0.0.0"/8;
    "172.16.0.0"/12;
    "192.168.0.0"/16;
}

sub vcl_recv {
    if (req.method == "PURGE") {
        if (!client.ip ~ purge) { return (synth(405, "Not Allowed")); }
        return (purge);
    }
    if (req.method == "BAN") {
        if (!client.ip ~ purge) { return (synth(405, "Not Allowed")); }
        if (req.http.X-Magento-Tags-Pattern) {
            ban("obj.http.X-Magento-Tags ~ " + req.http.X-Magento-Tags-Pattern);
        }
        return (synth(200, "Banned"));
    }
    if (req.method != "GET" && req.method != "HEAD") { return (pass); }
    if (req.url ~ "^/dynasecure") { return (pass); }
    if (req.url ~ "^/rest/" || req.url ~ "^/soap/") { return (pass); }
    if (req.url ~ "\.(css|js|png|gif|jpg|jpeg|ico|woff|woff2|ttf|svg)(\?.*)?$") {
        unset req.http.Cookie;
        return (hash);
    }
    if (req.http.Cookie ~ "PHPSESSID=|frontend=|adminhtml=|checkout=|private_content_version=") {
        return (pass);
    }
    unset req.http.Cookie;
    return (hash);
}

sub vcl_hash {
    hash_data(req.url);
    if (req.http.host) { hash_data(req.http.host); } else { hash_data(server.ip); }
    if (req.http.X-Forwarded-Proto) { hash_data(req.http.X-Forwarded-Proto); }
    return (lookup);
}

sub vcl_backend_response {
    if (beresp.status >= 500) { return (abandon); }
    if (bereq.url ~ "\.(css|js|png|gif|jpg|jpeg|ico|woff|woff2|ttf|svg)(\?.*)?$") {
        unset beresp.http.Set-Cookie;
        set beresp.ttl   = 1d;
        set beresp.grace = 1h;
        return (deliver);
    }
    if (beresp.http.Cache-Control ~ "(private|no-cache|no-store)") { return (pass); }
    set beresp.ttl   = 120s;
    set beresp.grace = 30s;
    unset beresp.http.Set-Cookie;
    return (deliver);
}

sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Varnish-Cache = "HIT";
    } else {
        set resp.http.X-Varnish-Cache = "MISS";
    }
    unset resp.http.X-Powered-By;
    return (deliver);
}
