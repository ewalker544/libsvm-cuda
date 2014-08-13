NVCC = nvcc
CXX = icpc

COMPAT_FLAGS=-Xcompiler "-O3"
INCLUDE_FLAG=-I../libsvm
CCBIN_FLAG = -ccbin=$(CXX)
CCFLAGS := $(CCBIN_FLAG) -m64 -O3
LDFLAGS := $(CCBIN_FLAG) -m64 -O3 
GENCODE_FLAGS := -gencode arch=compute_30,code=sm_35
LIBRARIES := -L../libsvm -lsvm -lcudart

all: svm-train

svm-train.o: svm-train.c
	$(NVCC) $(INCLUDE_FLAG) $(CCFLAGS) $(COMPAT_FLAGS) $(GENCODE_FLAGS) -o $@ -c $<

svm-train: svm-train.o ../libsvm/libsvm.a
	$(NVCC) $(LDFLAGS) $(GENCODE_FLAGS) -o $@ $+ $(LIBRARIES)

clean:
	rm -f svm-train *.o
