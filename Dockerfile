FROM alpine:3.20

RUN apk add --no-cache \
    postgresql16-client \
    mariadb-client \
    gzip \
    bash \
    age \
    rclone \
    sqlite

COPY backup.sh /backup.sh
RUN chmod +x /backup.sh

VOLUME ["/backups"]

ENTRYPOINT ["/backup.sh"]
