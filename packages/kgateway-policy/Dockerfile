# Binary is compiled statically from the adjacent locked Go module.
FROM scratch
COPY --chmod=0555 policy /policy
USER 65532:65532
ENTRYPOINT ["/policy"]
