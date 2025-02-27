# coding: utf8
from __future__ import unicode_literals

cimport numpy as np
from cython.operator cimport dereference as deref
from libcpp.set cimport set as cppset

import functools
import numpy
from collections import OrderedDict
import srsly
from thinc.neural.util import get_array_module
from thinc.neural._classes.model import Model

from .strings cimport StringStore

from .strings import get_string_id
from .compat import basestring_, path2str
from .errors import Errors
from . import util


def unpickle_vectors(bytes_data):
    return Vectors().from_bytes(bytes_data)


class GlobalRegistry(object):
    """Global store of vectors, to avoid repeatedly loading the data."""
    data = {}

    @classmethod
    def register(cls, name, data):
        cls.data[name] = data
        return functools.partial(cls.get, name)

    @classmethod
    def get(cls, name):
        return cls.data[name]


cdef class Vectors:
    """Store, save and load word vectors.

    Vectors data is kept in the vectors.data attribute, which should be an
    instance of numpy.ndarray (for CPU vectors) or cupy.ndarray
    (for GPU vectors). `vectors.key2row` is a dictionary mapping word hashes to
    rows in the vectors.data table.

    Multiple keys can be mapped to the same vector, and not all of the rows in
    the table need to be assigned - so len(list(vectors.keys())) may be
    greater or smaller than vectors.shape[0].

    DOCS: https://spacy.io/api/vectors
    """
    cdef public object name
    cdef public object data
    cdef public object key2row
    cdef cppset[int] _unset

    def __init__(self, *, shape=None, data=None, keys=None, name=None):
        """Create a new vector store.

        shape (tuple): Size of the table, as (# entries, # columns)
        data (numpy.ndarray): The vector data.
        keys (iterable): A sequence of keys, aligned with the data.
        name (unicode): A name to identify the vectors table.
        RETURNS (Vectors): The newly created object.

        DOCS: https://spacy.io/api/vectors#init
        """
        self.name = name
        if data is None:
            if shape is None:
                shape = (0,0)
            data = numpy.zeros(shape, dtype="f")
        self.data = data
        self.key2row = OrderedDict()
        if self.data is not None:
            self._unset = cppset[int]({i for i in range(self.data.shape[0])})
        else:
            self._unset = cppset[int]()
        if keys is not None:
            for i, key in enumerate(keys):
                self.add(key, row=i)

    @property
    def shape(self):
        """Get `(rows, dims)` tuples of number of rows and number of dimensions
        in the vector table.

        RETURNS (tuple): A `(rows, dims)` pair.

        DOCS: https://spacy.io/api/vectors#shape
        """
        return self.data.shape

    @property
    def size(self):
        """The vector size i,e. rows * dims.

        RETURNS (int): The vector size.

        DOCS: https://spacy.io/api/vectors#size
        """
        return self.data.shape[0] * self.data.shape[1]

    @property
    def is_full(self):
        """Whether the vectors table is full.

        RETURNS (bool): `True` if no slots are available for new keys.

        DOCS: https://spacy.io/api/vectors#is_full
        """
        return self._unset.size() == 0

    @property
    def n_keys(self):
        """Get the number of keys in the table. Note that this is the number
        of all keys, not just unique vectors.

        RETURNS (int): The number of keys in the table.

        DOCS: https://spacy.io/api/vectors#n_keys
        """
        return len(self.key2row)

    def __reduce__(self):
        return (unpickle_vectors, (self.to_bytes(),))

    def __getitem__(self, key):
        """Get a vector by key. If the key is not found, a KeyError is raised.

        key (int): The key to get the vector for.
        RETURNS (ndarray): The vector for the key.

        DOCS: https://spacy.io/api/vectors#getitem
        """
        i = self.key2row[key]
        if i is None:
            raise KeyError(Errors.E058.format(key=key))
        else:
            return self.data[i]

    def __setitem__(self, key, vector):
        """Set a vector for the given key.

        key (int): The key to set the vector for.
        vector (ndarray): The vector to set.

        DOCS: https://spacy.io/api/vectors#setitem
        """
        i = self.key2row[key]
        self.data[i] = vector
        if self._unset.count(i):
            self._unset.erase(self._unset.find(i))

    def __iter__(self):
        """Iterate over the keys in the table.

        YIELDS (int): A key in the table.

        DOCS: https://spacy.io/api/vectors#iter
        """
        yield from self.key2row

    def __len__(self):
        """Return the number of vectors in the table.

        RETURNS (int): The number of vectors in the data.

        DOCS: https://spacy.io/api/vectors#len
        """
        return self.data.shape[0]

    def __contains__(self, key):
        """Check whether a key has been mapped to a vector entry in the table.

        key (int): The key to check.
        RETURNS (bool): Whether the key has a vector entry.

        DOCS: https://spacy.io/api/vectors#contains
        """
        return key in self.key2row

    def resize(self, shape, inplace=False):
        """Resize the underlying vectors array. If inplace=True, the memory
        is reallocated. This may cause other references to the data to become
        invalid, so only use inplace=True if you're sure that's what you want.

        If the number of vectors is reduced, keys mapped to rows that have been
        deleted are removed. These removed items are returned as a list of
        `(key, row)` tuples.

        shape (tuple): A `(rows, dims)` tuple.
        inplace (bool): Reallocate the memory.
        RETURNS (list): The removed items as a list of `(key, row)` tuples.

        DOCS: https://spacy.io/api/vectors#resize
        """
        if inplace:
            self.data.resize(shape, refcheck=False)
        else:
            xp = get_array_module(self.data)
            self.data = xp.resize(self.data, shape)
        filled = {row for row in self.key2row.values()}
        self._unset = cppset[int]({row for row in range(shape[0]) if row not in filled})
        removed_items = []
        for key, row in list(self.key2row.items()):
            if row >= shape[0]:
                self.key2row.pop(key)
                removed_items.append((key, row))
        return removed_items

    def keys(self):
        """RETURNS (iterable): A sequence of keys in the table."""
        return self.key2row.keys()

    def values(self):
        """Iterate over vectors that have been assigned to at least one key.

        Note that some vectors may be unassigned, so the number of vectors
        returned may be less than the length of the vectors table.

        YIELDS (ndarray): A vector in the table.

        DOCS: https://spacy.io/api/vectors#values
        """
        for row, vector in enumerate(range(self.data.shape[0])):
            if not self._unset.count(row):
                yield vector

    def items(self):
        """Iterate over `(key, vector)` pairs.

        YIELDS (tuple): A key/vector pair.

        DOCS: https://spacy.io/api/vectors#items
        """
        for key, row in self.key2row.items():
            yield key, self.data[row]

    def find(self, *, key=None, keys=None, row=None, rows=None):
        """Look up one or more keys by row, or vice versa.

        key (unicode / int): Find the row that the given key points to.
            Returns int, -1 if missing.
        keys (iterable): Find rows that the keys point to.
            Returns ndarray.
        row (int): Find the first key that points to the row.
            Returns int.
        rows (iterable): Find the keys that point to the rows.
            Returns ndarray.
        RETURNS: The requested key, keys, row or rows.
        """
        if sum(arg is None for arg in (key, keys, row, rows)) != 3:
            bad_kwargs = {"key": key, "keys": keys, "row": row, "rows": rows}
            raise ValueError(Errors.E059.format(kwargs=bad_kwargs))
        xp = get_array_module(self.data)
        if key is not None:
            key = get_string_id(key)
            return self.key2row.get(key, -1)
        elif keys is not None:
            keys = [get_string_id(key) for key in keys]
            rows = [self.key2row.get(key, -1.) for key in keys]
            return xp.asarray(rows, dtype="i")
        else:
            targets = set()
            if row is not None:
                targets.add(row)
            else:
                targets.update(rows)
            results = []
            for key, row in self.key2row.items():
                if row in targets:
                    results.append(key)
                    targets.remove(row)
            return xp.asarray(results, dtype="uint64")

    def add(self, key, *, vector=None, row=None):
        """Add a key to the table. Keys can be mapped to an existing vector
        by setting `row`, or a new vector can be added.

        key (int): The key to add.
        vector (ndarray / None): A vector to add for the key.
        row (int / None): The row number of a vector to map the key to.
        RETURNS (int): The row the vector was added to.

        DOCS: https://spacy.io/api/vectors#add
        """
        key = get_string_id(key)
        if row is None and key in self.key2row:
            row = self.key2row[key]
        elif row is None:
            if self.is_full:
                raise ValueError(Errors.E060.format(rows=self.data.shape[0],
                                                    cols=self.data.shape[1]))
            row = deref(self._unset.begin())
        self.key2row[key] = row
        if vector is not None:
            self.data[row] = vector
            if self._unset.count(row):
                self._unset.erase(self._unset.find(row))
        return row

    def most_similar(self, queries, *, batch_size=1024, n=1, sort=True):
        """For each of the given vectors, find the n most similar entries
        to it, by cosine.

        Queries are by vector. Results are returned as a `(keys, best_rows,
        scores)` tuple. If `queries` is large, the calculations are performed in
        chunks, to avoid consuming too much memory. You can set the `batch_size`
        to control the size/space trade-off during the calculations.

        queries (ndarray): An array with one or more vectors.
        batch_size (int): The batch size to use.
        n (int): The number of entries to return for each query.
        sort (bool): Whether to sort the n entries returned by score.
        RETURNS (tuple): The most similar entries as a `(keys, best_rows, scores)`
            tuple.
        """
        xp = get_array_module(self.data)

        vectors = self.data / xp.linalg.norm(self.data, axis=1, keepdims=True)

        best_rows = xp.zeros((queries.shape[0], n), dtype='i')
        scores = xp.zeros((queries.shape[0], n), dtype='f')
        # Work in batches, to avoid memory problems.
        for i in range(0, queries.shape[0], batch_size):
            batch = queries[i : i+batch_size]
            batch /= xp.linalg.norm(batch, axis=1, keepdims=True)
            # batch   e.g. (1024, 300)
            # vectors e.g. (10000, 300)
            # sims    e.g. (1024, 10000)
            sims = xp.dot(batch, vectors.T)
            best_rows[i:i+batch_size] = xp.argpartition(sims, -n, axis=1)[:,-n:]
            scores[i:i+batch_size] = xp.partition(sims, -n, axis=1)[:,-n:]

            if sort:
                sorted_index = xp.arange(scores.shape[0])[:,None],xp.argsort(scores, axis=1)[:,::-1]
                scores[i:i+batch_size] = scores[sorted_index]
                best_rows[i:i+batch_size] = best_rows[sorted_index]

        xp = get_array_module(self.data)
        row2key = {row: key for key, row in self.key2row.items()}
        keys = xp.asarray(
            [[row2key[row] for row in best_rows[i] if row in row2key] 
                    for i in range(len(queries)) ], dtype="uint64")
        return (keys, best_rows, scores)

    def from_glove(self, path):
        """Load GloVe vectors from a directory. Assumes binary format,
        that the vocab is in a vocab.txt, and that vectors are named
        vectors.{size}.[fd].bin, e.g. vectors.128.f.bin for 128d float32
        vectors, vectors.300.d.bin for 300d float64 (double) vectors, etc.
        By default GloVe outputs 64-bit vectors.

        path (unicode / Path): The path to load the GloVe vectors from.
        RETURNS: A `StringStore` object, holding the key-to-string mapping.

        DOCS: https://spacy.io/api/vectors#from_glove
        """
        path = util.ensure_path(path)
        width = None
        for name in path.iterdir():
            if name.parts[-1].startswith("vectors"):
                _, dims, dtype, _2 = name.parts[-1].split('.')
                width = int(dims)
                break
        else:
            raise IOError(Errors.E061.format(filename=path))
        bin_loc = path / "vectors.{dims}.{dtype}.bin".format(dims=dims, dtype=dtype)
        xp = get_array_module(self.data)
        self.data = None
        with bin_loc.open("rb") as file_:
            self.data = xp.fromfile(file_, dtype=dtype)
            if dtype != "float32":
                self.data = xp.ascontiguousarray(self.data, dtype="float32")
        if self.data.ndim == 1:
            self.data = self.data.reshape((self.data.size//width, width))
        n = 0
        strings = StringStore()
        with (path / "vocab.txt").open("r") as file_:
            for i, line in enumerate(file_):
                key = strings.add(line.strip())
                self.add(key, row=i)
        return strings

    def to_disk(self, path, **kwargs):
        """Save the current state to a directory.

        path (unicode / Path): A path to a directory, which will be created if
            it doesn't exists.

        DOCS: https://spacy.io/api/vectors#to_disk
        """
        xp = get_array_module(self.data)
        if xp is numpy:
            save_array = lambda arr, file_: xp.save(file_, arr, allow_pickle=False)
        else:
            save_array = lambda arr, file_: xp.save(file_, arr)
        serializers = OrderedDict((
            ("vectors", lambda p: save_array(self.data, p.open("wb"))),
            ("key2row", lambda p: srsly.write_msgpack(p, self.key2row))
        ))
        return util.to_disk(path, serializers, [])

    def from_disk(self, path, **kwargs):
        """Loads state from a directory. Modifies the object in place and
        returns it.

        path (unicode / Path): Directory path, string or Path-like object.
        RETURNS (Vectors): The modified object.

        DOCS: https://spacy.io/api/vectors#from_disk
        """
        def load_key2row(path):
            if path.exists():
                self.key2row = srsly.read_msgpack(path)
            for key, row in self.key2row.items():
                if self._unset.count(row):
                    self._unset.erase(self._unset.find(row))

        def load_keys(path):
            if path.exists():
                keys = numpy.load(str(path))
                for i, key in enumerate(keys):
                    self.add(key, row=i)

        def load_vectors(path):
            xp = Model.ops.xp
            if path.exists():
                self.data = xp.load(str(path))

        serializers = OrderedDict((
            ("key2row", load_key2row),
            ("keys", load_keys),
            ("vectors", load_vectors),
        ))
        util.from_disk(path, serializers, [])
        return self

    def to_bytes(self, **kwargs):
        """Serialize the current state to a binary string.

        exclude (list): String names of serialization fields to exclude.
        RETURNS (bytes): The serialized form of the `Vectors` object.

        DOCS: https://spacy.io/api/vectors#to_bytes
        """
        def serialize_weights():
            if hasattr(self.data, "to_bytes"):
                return self.data.to_bytes()
            else:
                return srsly.msgpack_dumps(self.data)

        serializers = OrderedDict((
            ("key2row", lambda: srsly.msgpack_dumps(self.key2row)),
            ("vectors", serialize_weights)
        ))
        return util.to_bytes(serializers, [])

    def from_bytes(self, data, **kwargs):
        """Load state from a binary string.

        data (bytes): The data to load from.
        exclude (list): String names of serialization fields to exclude.
        RETURNS (Vectors): The `Vectors` object.

        DOCS: https://spacy.io/api/vectors#from_bytes
        """
        def deserialize_weights(b):
            if hasattr(self.data, "from_bytes"):
                self.data.from_bytes()
            else:
                self.data = srsly.msgpack_loads(b)

        deserializers = OrderedDict((
            ("key2row", lambda b: self.key2row.update(srsly.msgpack_loads(b))),
            ("vectors", deserialize_weights)
        ))
        util.from_bytes(data, deserializers, [])
        return self
