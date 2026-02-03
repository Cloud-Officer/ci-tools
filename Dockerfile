# Use Ubuntu 24.04 as the base image
FROM ubuntu:24.04

# Labels
LABEL org.opencontainers.image.source=https://github.com/Cloud-Officer/ci-tools
LABEL org.opencontainers.image.description="This is a collection of tools to run locally or on a CI pipeline."
LABEL org.opencontainers.image.licenses=MIT

# Set the environment variable to noninteractive to avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Update and install dependencies
RUN \
	apt-get update && \
	apt-get install --no-install-recommends --yes \
		autoconf \
		autogen \
		automake \
		build-essential \
		ca-certificates \
		clang \
		curl \
		file \
		gcc \
		git \
		git-lfs \
		intltool \
		libtool \
		libtool-bin \
		make \
		pkg-config \
		ruby \
		ruby-all-dev \
		ruby-build \
		ruby-bundler \
		ruby-dev \
		ssh \
		sudo \
		unzip \
		wget \
		zip \
		&& \
	rm -rf /var/lib/apt/lists/*

# Install AWS dependencies
RUN \
	ssm_arch="$(test "$(uname -m)" = "x86_64" && echo "64bit" || echo "arm64")" && \
	cd /tmp/ && \
# install AWS CLI \
	curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && \
	unzip awscliv2.zip && \
	./aws/install && \
# download AWS CLI SSM plugin \
	curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_${ssm_arch}/session-manager-plugin.deb" -o "session-manager-plugin.deb" && \
# patch buggy AWS package (inject shebangs in shell scripts, fix permissions, fix missing file) \
	dpkg-deb --raw-extract session-manager-plugin.deb tmp-deb && \
	sed -i '1i #!/bin/sh' tmp-deb/DEBIAN/preinst && \
	sed -i '1i #!/bin/sh' tmp-deb/DEBIAN/postinst && \
	sed -i '1i #!/bin/sh' tmp-deb/DEBIAN/prerm && \
	sed -i '1i #!/bin/sh' tmp-deb/DEBIAN/postrm && \
	chmod 0755 tmp-deb/DEBIAN/pre* tmp-deb/DEBIAN/post* && \
	touch tmp-deb/usr/local/sessionmanagerplugin/seelog.xml && \
# install patched package \
	dpkg-deb --build tmp-deb session-manager-plugin.patched.deb && \
	dpkg -i session-manager-plugin.patched.deb && \
	rm -rf ./aws/ awscliv2.zip session-manager-plugin*deb

# Add user/group citools and add ubuntu user to that group
RUN useradd -m -s /bin/bash citools && echo 'citools ALL=(ALL) NOPASSWD:ALL' >>/etc/sudoers && adduser ubuntu citools

# Clone the soup repository
ADD https://github.com/Cloud-Officer/ci-tools.git /home/citools/ci-tools

# Install ci-tools dependencies and create a symlink
USER root
WORKDIR /home/citools/ci-tools
RUN chown -R citools:citools . && bundle install && ln -s "/home/citools/ci-tools/brew-resources.rb" "/usr/local/bin/brew-resources" && ln -s "/home/citools/ci-tools/cycle-keys.rb" "/usr/local/bin/cycle-keys" && ln -s "/home/citools/ci-tools/deploy.rb" "/usr/local/bin/deploy" && ln -s "/home/citools/ci-tools/encrypt-logs.rb" "/usr/local/bin/encrypt-logs" && ln -s "/home/citools/ci-tools/generate-codeowners" "/usr/local/bin/generate-codeowners" && ln -s "/home/citools/ci-tools/linters" "/usr/local/bin/linters" && ln -s "/home/citools/ci-tools/ssh-jump" "/usr/local/bin/ssh-jump" && ln -s "/home/citools/ci-tools/ssm-jump" "/usr/local/bin/ssm-jump"

# Entrypoint
USER citools
CMD ["bash", "-c", "sleep 86400"]
