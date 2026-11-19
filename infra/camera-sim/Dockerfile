FROM python:3-slim
WORKDIR /app
COPY sim.py .
EXPOSE 8000 8090 8554 3702/udp
CMD ["python", "-u", "sim.py"]
