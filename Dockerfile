# Use Ubuntu 24.04 as the base image
FROM ubuntu:24.04

# Labels
LABEL org.opencontainers.image.source=https://github.com/Cloud-Officer/ci-tools
LABEL org.opencontainers.image.description="This is a collection of tools to run locally or on a CI pipeline."
LABEL org.opencontainers.image.licenses=MIT

# Set the environment variable to noninteractive to avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Update and install dependencies
RUN apt-get update && apt-get install --no-install-recommends --yes autoconf autogen automake build-essential ca-certificates clang curl file gcc git git-lfs intltool libtool libtool-bin make pkg-config ruby ruby-all-dev ruby-build ruby-bundler ruby-dev sudo unzip wget zip && rm -rf /var/lib/apt/lists/*

# Add user soup
RUN useradd -m -s /bin/bash citools && echo 'citools ALL=(ALL) NOPASSWD:ALL' >>/etc/sudoers

# Clone the soup repository
USER citools
WORKDIR /home/citools
RUN git clone https://github.com/Cloud-Officer/ci-tools.git

# Install ci-tools dependencies and create a symlink
USER root
WORKDIR /home/citools/ci-tools
RUN bundle install && ln -s "/home/citools/ci-tools/brew-resources.rb" "/usr/local/bin/brew-resources" && ln -s "/home/citools/ci-tools//cycle-keys.rb" "/usr/local/bin/cycle-keys" && ln -s "/home/citools/ci-tools/deploy.rb" "/usr/local/bin/deploy" && ln -s "/home/citools/ci-tools/encrypt-logs.rb" "/usr/local/bin/encrypt-logs" && ln -s "/home/citools/ci-tools/generate-codeowners" "/usr/local/bin/generate-codeowners" && ln -s "/home/citools/ci-tools/linters" "/usr/local/bin/linters" && ln -s "/home/citools/ci-tools/ssh-jump" "/usr/local/bin/ssh-jump"

# Entrypoint
USER citools
CMD ["bash", "-c", "sleep 86400"]