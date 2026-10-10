# The setup container: Docker's own CLI image, with what the chassis needs
# (nsenter for the few root-on-DSM things; sqlite3 and argon2 for apps that keep SQLite databases or hashed tokens;
# qrencode for QR codes the window shows, such as a server address for a phone app).
FROM docker:27-cli
RUN apk add --no-cache bash curl iproute2 coreutils gawk tar gzip procps tzdata jq util-linux-misc openssl sqlite argon2 libqrencode-tools
