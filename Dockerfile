FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    hugo \
 && rm -rf /var/lib/apt/lists/*

RUN cd /srv && hugo new site hugo && \
    cd hugo && \
    git init && \
    git submodule add https://github.com/budparr/gohugo-theme-ananke.git themes/ananke && \
    echo 'theme = "ananke"' >> config.toml

COPY hello.md /srv/hugo/content/posts/hello.md

WORKDIR /srv/hugo
ENTRYPOINT ["/usr/bin/hugo","server", "--bind", "0.0.0.0"]
