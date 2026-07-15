# DevHints -- offline developer cheatsheets. The Astro build runs a Ruby kramdown pre-cache step,
# so the builder carries both Node 22 and Ruby; the static output is dist/. Self-contained.
FROM node:22-bookworm AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends ruby ruby-dev build-essential git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/rstacruz/cheatsheets.git .
RUN gem install bundler && bundle install
RUN (npm ci || npm install) && npm run build

FROM nginx:1.27-alpine
COPY default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/dist /usr/share/nginx/html
