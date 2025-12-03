#!/bin/sh
for c in $(docker ps -a --format '{{.Names}}' | grep alm); do
  img_id=$(docker inspect --format '{{.Image}}' $c 2>/dev/null)
  if [ -n "$img_id" ]; then
    state=$(docker inspect --format '{{.State.Status}}' $c)
    state_time=$(docker inspect --format '{{if eq .State.Status "running"}}{{.State.StartedAt}}{{else}}{{.State.FinishedAt}}{{end}}' $c)
    size_bytes=$(docker inspect --format '{{.Size}}' $img_id)
    size_mb=$(echo $size_bytes | awk '{printf "%.2f", $1/1048576}')
    repo=$(docker inspect --format '{{if .RepoTags}}{{index .RepoTags 0}}{{else}}{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}none{{end}}{{end}}' $img_id)
    digest=$(docker inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}none{{end}}' $img_id)
    created=$(docker inspect --format '{{.Created}}' $img_id)
    
    jq -n \
      --arg c "$c" \
      --arg r "$repo" \
      --arg d "$digest" \
      --arg cr "$created" \
      --arg sm "$size_mb" \
      --arg s "$state" \
      --arg st "$state_time" \
      '{img_container: $c, img_repository: $r, img_digest: $d, img_created: $cr, img_size_mb: $sm, img_state: $s, img_state_time: $st}'
  fi
done
