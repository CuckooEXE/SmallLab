#!/bin/sh
# localize-assets.sh -- rewrite explainshell's web templates so every CSS/JS
# asset loads from the locally-baked /static tree instead of a public CDN, so
# the UI renders in an air-gapped lab.
#
# Upstream base.html/explain.html select asset URLs from config.DEBUG:
# DEBUG-on -> local /static/*, DEBUG-off -> cdnjs/maxcdn/googleapis. The lab
# image runs DEBUG=false on purpose (production store, no debug blueprint or
# debug panels), so we can't just flip DEBUG to get local assets -- it also
# gates unrelated behaviour. Instead we rewrite the CDN URLs (which appear
# ONLY in the DEBUG-off branches) to their baked-in local equivalents, leaving
# the config.DEBUG conditionals -- and the debug panels they also guard --
# untouched. Caddy already serves /static/* from explainshell/web/static/.
#
# Run from WORKDIR /opt/webapp (templates at explainshell/web/templates,
# assets at explainshell/web/static). Fails loud if any known CDN reference
# survives or a target asset is missing, so upstream drift breaks the build
# here rather than silently reintroducing an outbound request.
set -eu

TPL="explainshell/web/templates"
STATIC="explainshell/web/static"

# CDN URL -> local static path (protocol-relative //host/... forms only exist
# in the DEBUG-off branches, so this doesn't touch the local branches).
sed -i \
  -e 's#//maxcdn.bootstrapcdn.com/bootswatch/2.3.1/cyborg/bootstrap.min.css#/static/css/bootstrap-cyborg.min.css#g' \
  -e 's#//cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/2.3.1/css/bootstrap.min.css#/static/css/bootstrap.min.css#g' \
  -e 's#//cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.min.css#/static/css/hljs-atom-one-dark.min.css#g' \
  -e 's#//cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/default.min.css#/static/css/highlight.default.min.css#g' \
  -e 's#//cdnjs.cloudflare.com/ajax/libs/font-awesome/3.2.1/css/font-awesome.min.css#/static/css/font-awesome.min.css#g' \
  -e 's#//cdnjs.cloudflare.com/ajax/libs/jquery/1.9.1/jquery.min.js#/static/js/jquery.js#g' \
  -e 's#//cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/2.3.1/js/bootstrap.min.js#/static/js/bootstrap.min.js#g' \
  -e 's#//cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js#/static/js/highlight.min.js#g' \
  "$TPL/base.html"

sed -i \
  -e 's#//cdnjs.cloudflare.com/ajax/libs/d3/3.1.6/d3.min.js#/static/js/d3.v3.min.js#g' \
  "$TPL/explain.html"

# Berkshire Swash is a decorative webfont for the logo, loaded unconditionally
# from Google Fonts with no local copy and no functional role. Drop the <link>
# so nothing reaches fonts.googleapis.com; the logo falls back to es.css's
# font stack.
sed -i '\#fonts.googleapis.com#d' "$TPL/base.html"

# Fail loud if any outbound asset reference survived (the github.com project
# link in base.html is not a CDN and is intentionally left in place).
if grep -rnE '(cdnjs\.cloudflare\.com|maxcdn\.bootstrapcdn\.com|fonts\.googleapis\.com)' "$TPL"; then
  echo "localize-assets: CDN reference survived rewrite (upstream template drift?)" >&2
  exit 1
fi

# Verify every local asset the templates now point at exists in the baked tree.
for f in \
  css/bootstrap.min.css css/bootstrap-cyborg.min.css \
  css/highlight.default.min.css css/hljs-atom-one-dark.min.css \
  css/font-awesome.min.css \
  js/jquery.js js/bootstrap.min.js js/highlight.min.js js/d3.v3.min.js; do
  [ -f "$STATIC/$f" ] || { echo "localize-assets: missing baked asset $STATIC/$f" >&2; exit 1; }
done

echo "localize-assets: templates now reference local /static assets only"
