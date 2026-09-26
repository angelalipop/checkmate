FROM dart:3.13

RUN apt-get update && apt-get install -y \
    cmake \
    ninja-build \
    build-essential \
    git \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN dart pub global activate dart_frog_cli
ENV PATH="/root/.pub-cache/bin:${PATH}"

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .

# Generate the Dart Frog production application.
RUN dart_frog build

WORKDIR /app/build

RUN dart pub get

# Compile the generated Dart Frog server as a deployable CLI bundle.
# dartcv4's native assets are placed in the bundle's lib directory.
RUN dart build cli \
    --target=bin/server.dart \
    --output=/app/server_bundle

EXPOSE 8080

CMD ["/app/server_bundle/bundle/bin/server"]
