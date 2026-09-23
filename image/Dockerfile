# graphify MCP server, built from a pinned upstream commit with a locked dependency set, so a
# rebuild always reproduces the image that last worked. Upgrade via `docker-compose.ps1 relock`.
FROM python:3.12-slim@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9

WORKDIR /app
COPY --from=graphify-source . /app
COPY requirements.lock /tmp/requirements.lock

# --no-deps on both: only the locked versions are ever installed, nothing is re-resolved.
RUN pip install --no-cache-dir --no-deps -r /tmp/requirements.lock \
 && pip install --no-cache-dir --no-deps /app

RUN useradd --create-home --uid 10001 graphify
USER graphify

EXPOSE 8080

ENTRYPOINT ["python", "-m", "graphify.serve"]
CMD ["/data/graph.json", "--transport", "http", "--host", "0.0.0.0", "--port", "8080"]
