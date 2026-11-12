#!/usr/bin/env python3
"""Native owner/ALPN/stream witness; requires h2==4.3.0 and OpenSSL CLI."""
import host_process
from transport_h2_cases import main


if __name__ == "__main__":
    host_process.enter()
    main()
