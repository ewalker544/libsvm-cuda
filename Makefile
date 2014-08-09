SUBDIRS = libsvm svm-train

all: libsvm svm-train
	mkdir -p bin/
	cp -f libsvm/libsvm.a bin/
	cp -f svm-train/svm-train bin/

libsvm: 
	$(MAKE) -C $@

svm-train: 
	$(MAKE) -C $@

.PHONY: $(SUBDIRS)

clean:
	cd libsvm && $(MAKE) clean
	cd svm-train && $(MAKE) clean

realclean: clean
	rm -rf bin/	
