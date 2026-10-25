package measurement

import (
	"encoding/binary"
	"os"
	"testing"
)

// observationFrame encodes one record as src/TestObservation.zig writes it.
func observationFrame(lost byte, sequence uint64, fields map[byte]string) []byte {
	frame := make([]byte, observationHeaderBytes)
	for id := byte(0); int(id) < len(observationFields); id++ {
		if value, ok := fields[id]; ok {
			frame = append(frame, id, byte(len(value)), byte(len(value)>>8))
			frame = append(frame, value...)
		}
	}
	binary.LittleEndian.PutUint16(frame, uint16(len(frame)))
	frame[2], frame[3] = 1, lost
	binary.LittleEndian.PutUint64(frame[4:], sequence)
	binary.LittleEndian.PutUint64(frame[12:], 7)
	binary.LittleEndian.PutUint64(frame[20:], 42)
	return frame
}

func TestObservationsExposeOnlyTheCompleteSequencePrefix(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	state, err := os.CreateTemp(t.TempDir(), "state")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Truncate(observationStateBytes); err != nil {
		t.Fatal(err)
	}
	observations := &Observations{state: state, pending: map[uint64]map[string]any{}}
	done := make(chan struct{})
	go func() {
		observations.read(reader)
		close(done)
	}()
	// Field 9 is command_key and field 13 lock_acquired_at_ns.
	writer.Write(observationFrame(0, 2, map[byte]string{0: "control_timing", 9: "second"}))
	writer.Write(observationFrame(0, 1, map[byte]string{0: "control_timing", 9: "first", 13: "11"}))
	writer.Close()
	<-done
	records, err := observations.Phase("control_timing")
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 2 || records[0]["command_key"] != "first" || records[0]["lock_acquired_at_ns"] != "11" ||
		records[1]["command_key"] != "second" || records[0]["process"] != "42" || records[0]["run"] != "7" {
		t.Fatalf("records = %v", records)
	}
	var loss [8]byte
	loss[0] = 1
	if _, err := state.WriteAt(loss[:], observationLossOffset); err != nil {
		t.Fatal(err)
	}
	if _, err := observations.Phase("control_timing"); err == nil {
		t.Fatal("sticky native loss did not invalidate the records")
	}
}

func TestObservationDecodingRejectsLossAndMalformedFields(t *testing.T) {
	if _, _, err := decodeObservation(observationFrame(1, 1, map[byte]string{0: "settlement_complete"})); err == nil {
		t.Fatal("a frame carrying loss decoded")
	}
	if _, _, err := decodeObservation(observationFrame(0, 1, map[byte]string{9: "no phase"})); err == nil {
		t.Fatal("a frame without its phase decoded")
	}
	unknown := observationFrame(0, 1, map[byte]string{0: "settlement_complete"})
	unknown = append(unknown, byte(len(observationFields)), 0, 0)
	binary.LittleEndian.PutUint16(unknown, uint16(len(unknown)))
	if _, _, err := decodeObservation(unknown); err == nil {
		t.Fatal("an unknown field ID decoded")
	}
}
