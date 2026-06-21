# GTFOBins -- offline Unix living-off-the-land reference. Builds the upstream Jekyll site (its
# Gemfile pins jekyll via the github-pages gem). A clean ruby base avoids the jekyll/jekyll
# image's bundler-permission quirk; the committed lockfile is dropped so bundler resolves fresh.
FROM ruby:3.3-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends git build-essential \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /site
RUN git clone --depth 1 https://github.com/GTFOBins/GTFOBins.github.io.git . \
 && rm -f Gemfile.lock \
 && bundle install \
 && bundle exec jekyll build -d _site

# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
COPY --from=build /site/_site /usr/share/nginx/html
