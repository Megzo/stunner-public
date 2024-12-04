# Running STUNner as a public TURN server

## TL;DR

Set up environment variables:
```
export TLS_HOSTNAME="publicstunner.example.com"  # DNS should point to the VM 
export ISSUER_EMAIL="info@mycompany.io"          # Email for Let's Encrypt
export TURN_USER="stunner-user"                  # Default TURN username
export TURN_PASSWORD="stunner-password"          # Default TURN password
```

Run the install script:
```
curl -sfL https://raw.githubusercontent.com/Megzo/stunner-public/refs/heads/main/stunner-public.sh | sh -
```

Read more in my [blog post]().