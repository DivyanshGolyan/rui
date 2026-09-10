"""Throwaway observation benchmark, not OnePage's protocol implementation."""
import json, multiprocessing as mp, socket, sqlite3, statistics, tempfile, time
from pathlib import Path

def lookup(db, ids):
    return [db.execute('SELECT id,status FROM work WHERE id=?', (i,)).fetchone() for i in ids]

def serve(dbpath, sockpath, ready):
    db=sqlite3.connect(dbpath)
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(sockpath);listener.listen();ready.set()
        conn,_=listener.accept()
        with conn, conn.makefile('rwb') as f:
            for line in f:
                ids=json.loads(line)
                if ids is None: break
                f.write(json.dumps(lookup(db,ids),separators=(',',':')).encode()+b'\n');f.flush()
    db.close()

def main():
    results=[]
    with tempfile.TemporaryDirectory(prefix='op-observe-') as tmp:
        dbpath=str(Path(tmp)/'core.sqlite');sockpath=str(Path(tmp)/'socket')
        db=sqlite3.connect(dbpath)
        db.execute('CREATE TABLE work(id INTEGER PRIMARY KEY,status TEXT NOT NULL)')
        db.executemany('INSERT INTO work VALUES(?,?)',((i,'pending') for i in range(100000)))
        db.commit()
        ready=mp.Event();proc=mp.Process(target=serve,args=(dbpath,sockpath,ready));proc.start()
        assert ready.wait(10)
        with socket.socket(socket.AF_UNIX) as conn:
            conn.connect(sockpath)
            with conn.makefile('rwb') as f:
                def rpc(ids):
                    f.write(json.dumps(ids).encode()+b'\n');f.flush()
                    return json.loads(f.readline())
                for n in (1,16,64,256):
                    ids=[(i*379)%100000 for i in range(n)]
                    expected=[[i,'pending'] for i in ids]
                    times={k:[] for k in ('local_queries','socket_scalar','socket_batch')}
                    for repeat in range(23):
                        # Rotate ordering to reduce consistent warmup/order bias.
                        modes=list(times);modes=modes[repeat%3:]+modes[:repeat%3]
                        for mode in modes:
                            start=time.perf_counter_ns()
                            if mode=='local_queries': value=[list(row) for row in lookup(db,ids)]
                            elif mode=='socket_scalar': value=[rpc([i])[0] for i in ids]
                            else: value=rpc(ids)
                            elapsed=(time.perf_counter_ns()-start)/1e6
                            assert value==expected
                            if repeat>=3:times[mode].append(elapsed)
                    for mode,values in times.items():
                        results.append(dict(items=n,mode=mode,median_ms=round(statistics.median(values),4),max_ms=round(max(values),4),samples=len(values)))
                f.write(b'null\n');f.flush()
        proc.join(10);assert proc.exitcode==0;db.close()
    print(json.dumps(dict(rows=100000,sql_per_refresh='N in every mode',results=results),indent=2))
if __name__=='__main__':main()
