# Slim, not alpine: the grpc wheel for OTLP export is manylinux, and alpine's
# musl would force a source build of grpcio (slow, and it needs a toolchain).
FROM python:3.12-slim

WORKDIR /app
# Requirements first so a code edit doesn't re-resolve every wheel.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py .

# Non-root. python:slim has no unprivileged user by default, so make one.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin agent
USER 10001

ENTRYPOINT ["python", "-u", "agent.py"]
