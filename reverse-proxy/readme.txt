## docker run

```
docker run -d --restart=unless-stopped --log-opt max-size=100m --log-opt max-file=7 --name nginx --net host -v ~/nginx/nginx.conf:/etc/nginx/nginx.conf:ro -v ~/nginx/certs/:/etc/nginx/certs/:ro nginx
```

## SG setting
- 6080
- 443