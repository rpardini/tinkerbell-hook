# Get the latest built Armbian kernel for a given family (families are arch-specific)


```shell
skopeo list-tags docker://ghcr.io/armbian/os/kernel-arm64-current | jq -r ".Tags[]" | tail -1
```


