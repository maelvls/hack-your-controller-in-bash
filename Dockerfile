FROM alpine:3.16

# Why "setcap -r": https://github.com/hashicorp/vault/issues/10924
RUN echo "@testing http://dl-cdn.alpinelinux.org/alpine/edge/testing" | tee -a /etc/apk/repositories \
    && apk add --update --no-cache bash jq kubectl@testing vault libcap \
    && setcap -r /usr/sbin/vault

COPY controller.sh /usr/local/bin/controller.sh
CMD ["controller.sh"]
