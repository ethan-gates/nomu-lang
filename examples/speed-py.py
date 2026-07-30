import time

def test_speed():
    start_time = time.time()
    count = 1

    # 100 million iterations
    for i in range(10000):
        for j in range(10000):
            if count > 10000:
                count = (count - i) // 2
            else:
                count = (count + j) * 3

    end_time = time.time()
    print(f"Python Time: {end_time - start_time:.4f} seconds")

test_speed()
