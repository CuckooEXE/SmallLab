# LOLBAS -- offline Windows living-off-the-land reference. The lolbas-project.github.io site is
# its OWN Jekyll repo (the LOLBAS data repo's CI generates the _lolbas collection into it), so
# build that repo -- not the data-only LOLBAS repo. Self-contained.
FROM ruby:3.3-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends git build-essential \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /site
RUN git clone --depth 1 https://github.com/LOLBAS-Project/LOLBAS-Project.github.io.git . \
 && rm -f Gemfile.lock \
 && bundle install \
 && bundle exec jekyll build -d _site

FROM nginx:1.27-alpine
COPY --from=build /site/_site /usr/share/nginx/html
