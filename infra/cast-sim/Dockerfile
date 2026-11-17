FROM python:3-slim
RUN pip install --no-cache-dir zeroconf cryptography
WORKDIR /app
COPY sim.py .
EXPOSE 8082
CMD ["python", "-u", "sim.py"]
