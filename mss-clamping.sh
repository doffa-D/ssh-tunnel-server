#!/bin/bash
# MSS Clamping Configuration
# This prevents packet fragmentation in SSH tunnels
# 
# Add this rule to prevent MTU issues that cause the "4Mbps limit"
# The rule clamps TCP MSS to the Path MTU, preventing fragmentation

# Apply MSS clamping rule
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Make persistent (Ubuntu/Debian with iptables-persistent)
# apt install -y iptables-persistent
# netfilter-persistent save
