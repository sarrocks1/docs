# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3.20
ARG GO_VERSION=1.22
ARG HTMLTEST_VERSION=0.17.0

FROM golang:${GO_VERSION}-alpine AS base
WORKDIR /src
RUN apk --update add nodejs npm git gcompat

FROM base AS node
COPY package*.json .
ENV NODE_ENV=production
RUN npm install

FROM base AS hugo
ARG HUGO_VERSION=0.127.0
ARG TARGETARCH
WORKDIR /tmp/hugo
RUN wget -O "hugo.tar.gz" "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-${TARGETARCH}.tar.gz"
RUN tar -xf "hugo.tar.gz" hugo

FROM base AS build-base
COPY --from=hugo /tmp/hugo/hugo /bin/hugo
COPY --from=node /src/node_modules /src/node_modules
COPY . .

FROM build-base AS dev

FROM build-base AS build
ARG HUGO_ENV
ARG DOCS_URL
RUN hugo --gc --minify -d /out -e $HUGO_ENV -b $DOCS_URL

FROM davidanson/markdownlint-cli2:v0.12.1 AS lint
USER root
RUN --mount=type=bind,target=. \
    /usr/local/bin/markdownlint-cli2 \
    "content/**/*.md" \
    "#content/engine/release-notes/*.md" \
    "#content/desktop/previous-versions/*.md"

FROM wjdp/htmltest:v${HTMLTEST_VERSION} AS test
WORKDIR /test
COPY --from=build /out ./public
ADD .htmltest.yml .htmltest.yml
RUN htmltest

FROM build-base AS update-modules
ARG MODULE
RUN <<"EOT"
set -ex
if [ -n "$MODULE" ]; then
    hugo mod get ${MODULE}
    RESOLVED=$(cat go.mod | grep -m 1 "${MODULE/@*/}" | awk '{print $1 "@" $2}')
    go mod edit -replace "${MODULE/@*/}=${RESOLVED}";
else
    echo "no module set";
fi
EOT
RUN hugo mod vendor

FROM scratch AS vendor
COPY --from=update-modules /src/_vendor /_vendor
COPY --from=update-modules /src/go.* /

FROM build-base AS build-upstream
ARG UPSTREAM_MODULE_NAME
ARG UPSTREAM_REPO
ARG UPSTREAM_COMMIT
ENV HUGO_MODULE_REPLACEMENTS="github.com/${UPSTREAM_MODULE_NAME} -> github.com/${UPSTREAM_REPO} ${UPSTREAM_COMMIT}"
RUN hugo --ignoreVendorPaths "github.com/${UPSTREAM_MODULE_NAME}" -d /out

FROM wjdp/htmltest:v${HTMLTEST_VERSION} AS validate-upstream
WORKDIR /test
COPY --from=build-upstream /out ./public
ADD .htmltest.yml .htmltest.yml
RUN htmltest

FROM alpine:${ALPINE_VERSION} AS unused-media
RUN apk add --no-cache fd ripgrep
WORKDIR /test
RUN --mount=type=bind,target=. <<"EOT"
set -ex
./scripts/test_unused_media.sh
EOT

FROM base as pagefind
ARG PAGEFIND_VERSION=1.1.0
COPY --from=build /out ./public
RUN --mount=type=bind,src=pagefind.yml,target=pagefind.yml \
    npx pagefind@v${PAGEFIND_VERSION} --output-path "/pagefind"

FROM scratch AS index
COPY --from=pagefind /pagefind .

FROM scratch AS release
COPY --from=build /out /
COPY --from=pagefind /pagefind /pagefind

FROM alpine:${ALPINE_VERSION} AS test-go-redirects
WORKDIR /work
RUN apk add yq
COPY --from=build /out ./public
RUN --mount=type=bind,target=. <<"EOT"
set -ex
./scripts/test_go_redirects.sh
EOT
