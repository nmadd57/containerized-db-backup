FROM alpine:3.23

RUN apk add --no-cache \
    postgresql14-client \
    mariadb-client \
    gzip \
    bash

COPY backup.sh /backup.sh
RUN chmod +x /backup.sh

VOLUME ["/backups"]

ENTRYPOINT ["/backup.sh"]
