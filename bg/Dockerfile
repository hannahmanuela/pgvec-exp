FROM gcc:13

# Set working directory
WORKDIR /app

# Install build tools
RUN apt-get update && apt-get install -y wget cmake make libopencv-dev && rm -rf /var/lib/apt/lists/*

# Download httplib header (single header HTTP server)
RUN wget https://raw.githubusercontent.com/yhirose/cpp-httplib/master/httplib.h

# Copy and compile the app
COPY main.cc .
COPY 1.jpg .

RUN g++ -std=c++17 -o main main.cc `pkg-config --cflags --libs opencv4`

# Expose port
EXPOSE 3001

# Run the server
CMD ["./main"]
