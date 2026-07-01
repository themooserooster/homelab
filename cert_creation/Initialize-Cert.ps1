param(
    [Parameter(Mandatory = $true)]
    [string]$DomainName
)

Copy-Item -Path ./acme-dns-auth.py -Destination /etc/letsencrypt/

& certbot certonly `
    --manual `
    --manual-auth-hook /etc/letsencrypt/acme-dns-auth.py `
    --preferred-challenges dns `
    --debug-challenges `
    -d *.$DomainName `
    -d $DomainName `
    -v