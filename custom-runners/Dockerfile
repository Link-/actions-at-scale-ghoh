FROM summerwind/actions-runner:latest

# This will be a good place to add your CA bundle if you're using
# a custom CA.

# If you have proxy configurations, you can also add them here

# Change the work dir to tmp because these are disposable files
WORKDIR /tmp

# Install a stable version of Go
# and verify checksum of the tarball
# 
# Go releases URL: https://go.dev/dl/
#
RUN curl -OL https://go.dev/dl/go1.17.6.linux-amd64.tar.gz && \
    echo "231654bbf2dab3d86c1619ce799e77b03d96f9b50770297c8f4dff8836fc8ca2  go1.17.6.linux-amd64.tar.gz" | sha256sum -c - && \
    sudo tar -C /usr/local -xvf go1.17.6.linux-amd64.tar.gz && \
    echo "export PATH=$PATH:/usr/local/go/bin" >> /home/runner/.bashrc

# Sanity check
RUN export PATH=$PATH:/usr/local/go/bin && \
    go version