FROM python:3.12-slim
RUN pip install --no-cache-dir "paho-mqtt>=2.0,<3"
WORKDIR /app
COPY sim.py index.html ./
EXPOSE 8080
CMD ["python", "-u", "sim.py"]
