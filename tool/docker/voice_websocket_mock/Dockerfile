FROM debian:trixie-slim

COPY mock_voice_websocket_server /usr/local/bin/mock_voice_websocket_server
RUN chmod 0555 /usr/local/bin/mock_voice_websocket_server

USER 65532:65532
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/mock_voice_websocket_server"]
