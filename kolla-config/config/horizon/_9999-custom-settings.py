DEFAULT_THEME = 'lux'

# HTTPS do Horizon pelo frontend 443 do HAProxy (lab.sh cert cloud): o HAProxy avisa o Django pelo
# X-Forwarded-Proto, e o login por https://cloud.larcerto.com.br passa no CSRF. O HTTP continua valendo.
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
