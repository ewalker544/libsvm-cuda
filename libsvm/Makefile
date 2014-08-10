NVCC = nvcc
CXX = icpc

COMPAT_FLAG=-Xcompiler "-std=c++11"
CCBIN_FLAG = -ccbin=$(CXX)
CCFLAGS := $(CCBIN_FLAG) -m64 -O3
LDFLAGS := $(CCBIN_FLAG) -m64 -O3
#GENCODE2_FLAGS := -gencode arch=compute_20,code=sm_20
#GENCODE3_FLAGS := -gencode arch=compute_30,code=sm_35
GENCODE35_FLAGS := -gencode arch=compute_35,code=sm_35
GENCODE_FLAGS := $(GENCODE3_FLAGS) $(GENCODE35_FLAGS) $(GENCODE2_FLAGS)
LIBRARIES := -lcudart

all: libsvm.a

cuda_solver.o: cuda_solver.cpp cuda_solver.h svm_defs.h
	$(NVCC) $(INCLUDE_FLAG) $(CCFLAGS) $(COMPAT_FLAG) $(GENCODE_FLAGS) -o $@ -c $<

cuda_solverNU.o: cuda_solverNU.cpp cuda_solver.h cuda_solverNU.h svm_defs.h
	$(NVCC) $(INCLUDE_FLAG) $(CCFLAGS) $(COMPAT_FLAG) $(GENCODE_FLAGS) -o $@ -c $<

svm.o: svm.cpp svm.h
	$(NVCC) $(INCLUDE_FLAG) $(CCFLAGS) $(COMPAT_FLAG) $(GENCODE_FLAGS) -o $@ -c $<

svm_device.o: svm_device.cu svm_device.h svm_defs.h
	$(NVCC) $(INCLUDE_FLAG) $(CCFLAGS) $(GENCODE_FLAGS) -o $@ -c $<

libsvm.a: cuda_solver.o cuda_solverNU.o svm.o svm_device.o
	ar cr $@ $+ 
	ranlib $@

clean:
	rm -f libsvm.a *.o
