FROM alpine:3.20

RUN apk add --no-cache bash curl jq python3 tini

COPY crontab /etc/crontabs/aether
COPY renew-plans.sh /usr/local/bin/renew-plans.sh
RUN chmod +x /usr/local/bin/renew-plans.sh

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["crond", "-f", "-l", "2"]
