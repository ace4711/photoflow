# Objektfilm-servern. Byggkontext: repots rot (se compose.yaml).
#   docker build -f server/Dockerfile -t objektfilm .

# --- steg 1: bygg webbdelen (esbuild) ---
FROM node:24-bookworm-slim AS web
WORKDIR /build/web/reel
COPY web/reel/package.json web/reel/package-lock.json ./
RUN npm ci
COPY web/reel/ ./
RUN npm run build && rm -f dist/*.map

# --- steg 2: körmiljö, bara det som behövs (inga npm-beroenden i servern) ---
FROM node:24-bookworm-slim
ENV NODE_ENV=production \
    NODE_OPTIONS=--disable-warning=ExperimentalWarning \
    OBJEKTFILM_DATA_DIR=/data \
    OBJEKTFILM_PORT=8080 \
    OBJEKTFILM_METRICS_PORT=9471 \
    OBJEKTFILM_STATIC_DIR=/app/web/reel/dist
RUN groupadd --gid 10470 objektfilm \
 && useradd --uid 10470 --gid 10470 --no-create-home --shell /usr/sbin/nologin objektfilm \
 && mkdir /data && chown 10470:10470 /data
WORKDIR /app/server
COPY server/package.json ./
COPY server/src ./src
# Servern återanvänder specvalideringen och tidslinjen från webbdelen (samma relativa sökvägar som i repot).
COPY web/reel/src/reelSpec.ts web/reel/src/reelTimeline.ts /app/web/reel/src/
COPY --from=web /build/web/reel/dist /app/web/reel/dist
USER 10470:10470
VOLUME ["/data"]
EXPOSE 8080 9471
CMD ["node", "src/main.ts"]
