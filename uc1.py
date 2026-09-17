from datetime import datetime

def get_hello_message():
    # Format the current system time exactly as date/hh/mm/ss
    current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return f"Hello from Usecase-1 at {current_time}\n"

if __name__ == "__main__":
    # When run directly, it will execute and print the message to the console
    print(get_hello_message())
