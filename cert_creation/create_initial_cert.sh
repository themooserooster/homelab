#!/bin/sh
sudo cp ./acme-dns-auth.py /etc/letsencrypt

sudo certbot certonly \
    --manual \
    --manual-auth-hook /etc/letsencrypt/acme-dns-auth.py \
    --preferred-challenges dns \
    --debug-challenges \
    -d \*.your-domain \
    -d your-domain \
    -v