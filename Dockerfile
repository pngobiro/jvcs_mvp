FROM elixir:1.15.7

# Install build dependencies
RUN sed -i 's/main/main contrib non-free/g' /etc/apt/sources.list.d/debian.sources || \
    (echo "deb http://deb.debian.org/debian bookworm main contrib non-free" > /etc/apt/sources.list && \
     echo "deb http://deb.debian.org/debian-security bookworm-security main contrib non-free" >> /etc/apt/sources.list && \
     echo "deb http://deb.debian.org/debian bookworm-updates main contrib non-free" >> /etc/apt/sources.list)

RUN apt-get update && \
    apt-get install -y build-essential inotify-tools postgresql-client git curl pkg-config libavcodec-dev libavutil-dev libavformat-dev libswscale-dev libavdevice-dev libfdk-aac-dev libopus-dev libsrtp2-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*




# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

WORKDIR /app

# Copy the project files
COPY . .

# Install dependencies
RUN mix deps.get

# Compile the project
RUN mix compile

EXPOSE 4000

CMD ["mix", "phx.server"]
