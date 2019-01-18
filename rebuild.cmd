docker build -t yourapplication .
docker kill yourapplication
docker run --rm --name yourapplication -p 8080:80 yourapplication