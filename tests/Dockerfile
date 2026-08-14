# Build prerequisites for the registry's ports on Ubuntu 22.04.
# Baked into an image so repeat runs skip apt entirely; the containers themselves
# are --rm, so anything installed at run time would be lost.
#
# The package list lives in apt-packages.txt because the GitHub Actions workflow
# installs the same set — one list, so the two environments cannot drift.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

COPY apt-packages.txt /tmp/apt-packages.txt
RUN apt-get update -qq \
 && grep -v '^\s*#' /tmp/apt-packages.txt | grep -v '^\s*$' | xargs \
      apt-get install -y -qq --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* /tmp/apt-packages.txt
