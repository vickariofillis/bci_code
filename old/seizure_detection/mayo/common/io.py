import os
import hickle as hkl
import pickle
import common.time as time

def load_hkl_file(filename):
    hkl_filename = filename + '.hkl'
    if os.path.isfile(hkl_filename):
        start = time.get_seconds()
        data = hkl.load(hkl_filename)
        print('Loaded %s in %ds' % (hkl_filename, time.get_seconds() - start))
        return data
    return None


def save_hkl_file(filename, data):
    hkl_filename = filename + '.hkl'
    try:
        hkl.dump(data, hkl_filename, mode="w")
        return True
    except Exception:
        if os.path.isfile(filename):
            os.remove(hkl_filename)


def save_pickle_file(filename, data):
    start = time.get_seconds()
    filename = filename + '.pickle'
    print('Dumping to %s' % filename, end=' ')
    ## BCINOTE: Changed opening mode from 'w' to 'wb'
    with open(filename, 'wb') as f:
        pickle.dump(data, f)
        print('%ds' % (time.get_seconds() - start))


def load_pickle_file(filename):
    filename = filename + '.pickle'
    if os.path.isfile(filename):
        print('Loading %s ...' % filename, end=' ')
        ## BCINOTE: Needed to specify opening mode
        ## BCITODO: Originally (without try-except) prodcued EOFFile error, but doesn't seem like it should. Deeper issue?
        with open(filename, 'rb') as f:
            start = time.get_seconds()
            try:
                data = pickle.load(f)
            except:
                data = None
            print('%ds' % (time.get_seconds() - start))
            return data
    return None

